import SwiftUI

/// The screens that finish an answer: an item's full answers (from a tap on its notification, the alarm's Stop, or
/// Later on the Now card), Later -> Pick a time, Pick a day after the 3rd Later, and habit proof.
struct AnswerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let screen: AnswerScreen

    var body: some View {
        NavigationStack {
            Group {
                switch screen {
                case .answers(.reminder, let ids): ReminderAnswers(id: ids[0], done: close)
                case .answers(.habit, let ids): HabitAnswers(ids: ids, done: close)
                case .answers(.event, let ids): EventAnswers(id: ids[0], done: close)
                case .pickTime(let id): PickTime(id: id, done: close)
                case .pickDay(let id): PickDay(id: id, done: close)
                case .proof(let ids): ProofView(ids: ids, done: close)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { close() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func close() {
        model.notice = nil
        model.screen = nil
        dismiss()
    }
}

/// A full-width answer row.
struct AnswerRow: View {
    let action: AlertAction
    var label: String?
    var role: ButtonRole?
    let run: () -> Void

    var body: some View {
        Button(role: role, action: run) {
            Label(label ?? action.title, systemImage: action.symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
        .accessibilityIdentifier("answer-\(action.rawValue)")
    }
}

struct NoticeText: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let notice = model.notice {
            Text(notice).font(.footnote).foregroundStyle(.orange)
        }
    }
}

// MARK: - Reminder

struct ReminderAnswers: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let done: () -> Void

    var body: some View {
        if let r = model.reminder(id), r.status == .active {
            List {
                Section {
                    AnswerRow(action: .done) { answer(.done) }
                }
                if r.laterCount >= ReminderLogic.maxLaters {
                    Section {
                        AnswerRow(action: .pickDay) { model.screen = .pickDay(id) }
                        AnswerRow(action: .delete, role: .destructive) { answer(.delete) }
                    } footer: {
                        Text("Put off 3 times. Now it's done, a new day, or deleted.")
                    }
                } else {
                    Section {
                        ForEach(ReminderLogic.laterChoices(now: model.now, settings: model.data.settings,
                                                           calendar: model.calendar), id: \.self) { choice in
                            laterRow(choice, r)
                        }
                    } header: {
                        Text("Later")
                    } footer: {
                        Text("Later \(r.laterCount + 1) of \(ReminderLogic.maxLaters). Starts over at that time.")
                    }
                }
                Section { NoticeText() }
            }
            .navigationTitle(r.title)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Already answered", systemImage: "checkmark.circle")
        }
    }

    @ViewBuilder
    private func laterRow(_ choice: ReminderLaterChoice, _ r: Reminder) -> some View {
        let cal = model.calendar, s = model.data.settings
        switch choice {
        case .fifteenMinutes: AnswerRow(action: .later15, label: "15 min") { answer(.later(.fifteenMinutes)) }
        case .oneHour: AnswerRow(action: .later60, label: "1 hour") { answer(.later(.oneHour)) }
        case .tonight:
            AnswerRow(action: .tonight, label: "Tonight, \(Formats.time(s.tonightTime, calendar: cal))") {
                answer(.later(.tonight))
            }
        case .tomorrow:
            AnswerRow(action: .tomorrow,
                      label: "Tomorrow, \(Formats.time(TimeOfDay(of: r.occurrence, cal), calendar: cal))") {
                answer(.later(.tomorrow))
            }
        case .pickTime: AnswerRow(action: .pickTime, label: "Pick a time…") { model.screen = .pickTime(id) }
        }
    }

    private func answer(_ a: ReminderAnswer) {
        Task { if await model.answer(.reminder(id, a)) { done() } }
    }
}

struct PickTime: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let done: () -> Void
    @State private var date: Date?

    var body: some View {
        if let r = model.reminder(id) {
            Form {
                DatePicker("Remind me", selection: Binding(get: { date ?? Defaults.pickStart(for: r, now: model.now, calendar: model.calendar) },
                                                           set: { date = $0 }),
                           in: model.now..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                Button("Later to this time") {
                    let target = date ?? Defaults.pickStart(for: r, now: model.now, calendar: model.calendar)
                    Task { if await model.answer(.reminder(id, .later(.pick(target)))) { done() } }
                }
                .accessibilityIdentifier("pick-time-save")
                NoticeText()
            }
            .navigationTitle("Later: pick a time")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct PickDay: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let done: () -> Void
    @State private var day: Date?

    var body: some View {
        if let r = model.reminder(id) {
            let start = Defaults.pickStart(for: r, now: model.now, calendar: model.calendar)
            Form {
                DatePicker("Day", selection: Binding(get: { day ?? start }, set: { day = $0 }),
                           in: model.calendar.startOfDay(for: model.now)..., displayedComponents: [.date])
                    .datePickerStyle(.graphical)
                Section {
                    Button("Move to this day") {
                        Task { if await model.answer(.reminder(id, .pickDay(day ?? start))) { done() } }
                    }
                } footer: {
                    Text("Keeps its time, \(Formats.time(TimeOfDay(of: r.occurrence, model.calendar), calendar: model.calendar)), and starts the Later count over.")
                }
                NoticeText()
            }
            .navigationTitle("Pick a day")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Habit

struct HabitAnswers: View {
    @Environment(AppModel.self) private var model
    let ids: [UUID]
    let done: () -> Void

    var body: some View {
        let habits = ids.compactMap(model.habit).filter { !Answers.isProved($0, data: model.data, now: model.now, calendar: model.calendar) }
        if habits.isEmpty {
            ContentUnavailableView("All proved", systemImage: "checkmark.seal")
        } else {
            let choices = Set(habits.flatMap {
                Answers.habitChoices($0, data: model.data, context: model.phoneContext, now: model.now, calendar: model.calendar)
            })
            List {
                Section {
                    AnswerRow(action: .prove) { model.screen = .proof(habits.map(\.id)) }
                    if choices.contains(.fifteenMinutes) {
                        AnswerRow(action: .habit15) {
                            Task {
                                await model.apply(habits.map { .habit($0.id, .fifteenMinutes) })
                                done()
                            }
                        }
                    }
                    if choices.contains(.cantRightNow) {
                        AnswerRow(action: .cantRightNow) {
                            Task {
                                await model.apply(habits.compactMap { h in
                                    HabitLogic.pauseReason(h, context: model.phoneContext).map { AppAnswer.habit(h.id, .cantRightNow($0)) }
                                })
                                done()
                            }
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if !choices.contains(.fifteenMinutes) { Text("15 min is used for today.") }
                        if !choices.contains(.cantRightNow) {
                            Text("Can't right now is only for when you're driving or away from the habit's place.")
                        }
                        Text("It keeps ringing every \(model.data.settings.alarmEveryMinutes) min until proved or the window ends.")
                    }
                }
                Section { NoticeText() }
            }
            .navigationTitle(habits.count == 1 ? habits[0].name : "\(habits.count) habits")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Proof for one or more habits (a group alarm is a checklist). Real photo, location and NFC proof come in the next
/// build; until then each habit has a clearly marked stand-in button.
struct ProofView: View {
    @Environment(AppModel.self) private var model
    let ids: [UUID]
    let done: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(ids.compactMap(model.habit), id: \.id) { h in
                    let proved = Answers.isProved(h, data: model.data, now: model.now, calendar: model.calendar)
                    HStack {
                        Image(systemName: proved ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(proved ? .green : .secondary)
                            .font(.title3)
                        VStack(alignment: .leading) {
                            Text(h.name).font(.body.weight(.medium))
                            Text(proofName(h.proof)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !proved {
                            Button("Prove (stub)") {
                                Task {
                                    await model.answer(.habit(h.id, .done(ProofStub.evidence(for: h))))
                                    if ids.compactMap(model.habit).allSatisfy({
                                        Answers.isProved($0, data: model.data, now: model.now, calendar: model.calendar)
                                    }) { done() }
                                }
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("prove-\(h.name)")
                        }
                    }
                }
            } footer: {
                Text("Test build: the camera, location and NFC proof arrive in the next build. This button stands in for it.")
            }
            Section { NoticeText() }
        }
        .navigationTitle("Proof")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func proofName(_ p: ProofKind) -> String {
        switch p {
        case .photo: return "Photo of the spot"
        case .location: return "Being at the place"
        case .nfc: return "Scan the tag"
        }
    }
}

// MARK: - Event

struct EventAnswers: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let done: () -> Void

    var body: some View {
        if let e = model.event(id) {
            List {
                Section {
                    LabeledContent("Starts", value: Formats.when(e.start, now: model.now, calendar: model.calendar))
                    if let end = e.end { LabeledContent("Ends", value: Formats.when(end, now: model.now, calendar: model.calendar)) }
                }
                Section {
                    AnswerRow(action: .gotIt) {
                        let ringing = EventLogic.isRinging(e, now: model.now, settings: model.data.settings)
                        Task {
                            await model.answer(.event(id, ringing ? .gotItMainAlert : .gotItHeadsUp))
                            done()
                        }
                    }
                }
            }
            .navigationTitle(e.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
