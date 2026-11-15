import SwiftUI

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
    @State private var when = Date()
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
            if case .arrival? = original?.trigger {
                Section("When") { Text("When you arrive") }
            } else {
                Section("When") {
                    HStack(spacing: 8) {
                        ForEach(Defaults.quickTimes(now: model.now, settings: model.data.settings, calendar: model.calendar),
                                id: \.self) { q in
                            Button(q.label) { when = q.date }
                                .buttonStyle(.bordered)
                                .tint(abs(when.timeIntervalSince(q.date)) < 30 ? .accentColor : .secondary)
                        }
                    }
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    DatePicker("Time", selection: $when, displayedComponents: [.date, .hourAndMinute])
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
    }

    private var draftRule: RepeatRule { repeatChoice.rule(days: days) }
    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !(repeatChoice == .days && days.isEmpty)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let r = original else {
            when = Defaults.reminderTime(now: model.now, calendar: model.calendar)
            typing = true
            return
        }
        title = r.title
        when = r.due ?? r.occurrence
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
            if case .time = original.trigger { retimed = (original.due ?? original.occurrence) != when } else { retimed = false }
            if retimed || original.repeatRule != draftRule || original.status != .active {
                // New time or repeat: it starts over from there.
                let trigger: ReminderTrigger = retimed ? .time(when) : original.trigger
                r = Reminder(id: original.id, title: name, trigger: trigger, repeatRule: draftRule, createdAt: model.now)
            }
            r.title = name
        } else {
            r = Reminder(title: name, trigger: .time(when), repeatRule: draftRule, createdAt: model.now)
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
            if !model.data.places.isEmpty {
                Section("Place") {
                    Picker("Place", selection: $habit.placeID) {
                        Text("Anywhere").tag(UUID?.none)
                        ForEach(model.data.places) { p in Text(p.name).tag(UUID?.some(p.id)) }
                    }
                }
            }
            Section {
                Picker("Proof", selection: $habit.proof) {
                    Text("Photo of the spot").tag(ProofKind.photo)
                    Text("Location").tag(ProofKind.location)
                    Text("NFC tag").tag(ProofKind.nfc)
                }
                switch habit.proof {
                case .photo:
                    Button(habit.referencePhoto == nil ? "Take reference photo (stub)" : "Reference photo set (stub) ✓") {
                        habit.referencePhoto = "stub-reference"
                    }
                    .accessibilityIdentifier("habit-reference")
                case .nfc:
                    Button(habit.nfcTagID == nil ? "Scan tag (stub)" : "Tag set (stub) ✓") { habit.nfcTagID = "stub-tag" }
                case .location:
                    EmptyView()
                }
            } header: {
                Text("Proof")
            } footer: {
                Text(problemText ?? "Test build: the camera and NFC parts arrive in the next build; these buttons stand in.")
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
        let h = draft
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
            if !model.data.places.isEmpty {
                Section("Where") {
                    Picker("Place", selection: $event.placeID) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.data.places) { p in Text(p.name).tag(UUID?.some(p.id)) }
                    }
                }
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
                    ForEach(AlertChoice.allCases.filter { $0 != .leave || event.placeID != nil }) { Text($0.rawValue).tag($0) }
                }
            } footer: {
                Text("\(mainAlertText). Then an alarm every \(model.data.settings.alarmEveryMinutes) min until you answer.")
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
        .onChange(of: event.start) { old, new in
            // the end moves with the start
            if hasEnd { end = end.addingTimeInterval(new.timeIntervalSince(old)) }
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
        let d = draft
        let date = EventLogic.mainAlertDate(d, settings: model.data.settings)
        return "\(Planner.mainAlertText(d)) at \(Formats.time(date, calendar: model.calendar))"
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        event = original ?? Defaults.event(now: model.now, calendar: model.calendar)
        hasEnd = event.end != nil
        end = event.end ?? event.start.addingTimeInterval(3600)
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
        if let original, original.start != e.start || original.mainAlert != e.mainAlert {
            // a new time: its alerts start over
            e.mainAlertAnsweredAt = nil
            e.headsUpAcknowledgedAt = nil
        }
        Task { await model.save(e); dismiss() }
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
                            row(r.title, r.due.map { Formats.when($0, now: model.now, calendar: model.calendar) } ?? "When you arrive")
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
                            row(e.title, Formats.when(e.start, now: model.now, calendar: model.calendar))
                        }
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

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
