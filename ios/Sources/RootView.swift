import SwiftUI

/// The main screen: one Now card (the thing that matters right now), a small Today strip and the Upcoming events.
/// No long lists; everything else is one tap away (the + button, the list button for editing).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: Sheet?

    enum Sheet: Identifiable, Hashable {
        case add
        case everything
        case editReminder(UUID), editHabit(UUID), editEvent(UUID)
        var id: Self { self }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    NowCardView(card: model.nowCard, open: open)
                    TodayStrip(open: open)
                    UpcomingList(open: { sheet = .editEvent($0) })
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 100)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("GupDo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Everything", systemImage: "list.bullet") { sheet = .everything }
                        .accessibilityIdentifier("everything")
                }
            }
            .overlay(alignment: .bottom) {
                Button {
                    sheet = .add
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.glassProminent)
                .padding(.bottom, 12)
                .accessibilityIdentifier("add")
            }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .add: AddSheet()
            case .everything: EverythingView()
            case .editReminder(let id): if let r = model.reminder(id) { ReminderForm(editing: r) }
            case .editHabit(let id): if let h = model.habit(id) { HabitForm(editing: h) }
            case .editEvent(let id): if let e = model.event(id) { EventForm(editing: e) }
            }
        }
        .sheet(item: $model.screen) { screen in
            AnswerSheet(screen: screen)
        }
    }

    /// A tap on a Today chip or the Now card's title: the item's answers when it is ringing, else its setup.
    private func open(_ kind: ItemKind, _ ids: [UUID]) {
        guard let id = ids.first else { return }
        let ringing = model.nowCard.map { $0.ringing && Set($0.itemIDs).contains(id) } ?? false
        if ringing { model.screen = .answers(kind, ids); return }
        switch kind {
        case .reminder: sheet = .editReminder(id)
        case .habit: sheet = .editHabit(id)
        case .event: sheet = .editEvent(id)
        }
    }
}

extension AnswerScreen: Identifiable {
    var id: String { String(describing: self) }
}

// MARK: - Now

struct NowCardView: View {
    @Environment(AppModel.self) private var model
    let card: NowCard?
    let open: (ItemKind, [UUID]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                if card?.ringing == true {
                    Image(systemName: "bell.and.waves.left.and.right.fill")
                    Text("Now")
                } else {
                    Text(card == nil ? "Now" : "Next")
                }
                Spacer()
                if let card {
                    Text(card.ringing ? kindName(card.itemKind) : Formats.when(card.date, now: model.now, calendar: model.calendar))
                }
            }
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(card?.ringing == true ? Color.orange : .secondary)

            if let card {
                Button { open(card.itemKind, card.itemIDs) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.title)
                            .font(.title.weight(.bold))
                            .multilineTextAlignment(.leading)
                        if let detail = detail(card) {
                            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                if card.ringing {
                    AnswerButtons(kind: card.itemKind, ids: card.itemIDs)
                }
            } else {
                Text("Nothing right now")
                    .font(.title2.weight(.semibold))
                Text("Reminders, habits and events show up here when it's their time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card?.ringing == true ? Color.orange.opacity(0.14) : Color(.secondarySystemGroupedBackground),
                    in: .rect(cornerRadius: 24))
        .accessibilityIdentifier("now-card")
    }

    private func kindName(_ k: ItemKind) -> String {
        switch k {
        case .reminder: return "Reminder"
        case .habit: return "Habit"
        case .event: return "Event"
        }
    }

    private func detail(_ card: NowCard) -> String? {
        switch card.itemKind {
        case .reminder:
            guard let r = model.reminder(card.itemIDs[0]) else { return nil }
            var parts: [String] = []
            if card.ringing { parts.append("Since \(Formats.time(card.date, calendar: model.calendar))") }
            if r.laterCount > 0 { parts.append("Later \(r.laterCount) of \(ReminderLogic.maxLaters)") }
            if let note = r.note, !note.isEmpty { parts.append(note) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .habit:
            let habits = card.itemIDs.compactMap(model.habit)
            guard let h = habits.first else { return nil }
            let window = Formats.window(h.window, calendar: model.calendar)
            return habits.count > 1 ? habits.map(\.name).joined(separator: " · ") + "\n" + window : window
        case .event:
            guard let e = model.event(card.itemIDs[0]) else { return nil }
            if card.ringing { return "\(Planner.mainAlertText(e)) · starts \(Formats.time(e.start, calendar: model.calendar))" }
            return e.end.map { "Until \(Formats.time($0, calendar: model.calendar))" }
        }
    }
}

/// The answers for a ringing item, the same as on its notification and alarm.
struct AnswerButtons: View {
    @Environment(AppModel.self) private var model
    let kind: ItemKind
    let ids: [UUID]

    var body: some View {
        switch kind {
        case .reminder:
            if let r = model.reminder(ids[0]) {
                HStack(spacing: 10) {
                    Button { Task { await model.answer(.reminder(r.id, .done)) } } label: {
                        Label("Done", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("answer-done")
                    if r.laterCount >= ReminderLogic.maxLaters {
                        Button { model.screen = .answers(.reminder, [r.id]) } label: {
                            Label("More", systemImage: "ellipsis").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    } else {
                        Button { model.screen = .answers(.reminder, [r.id]) } label: {
                            Label("Later", systemImage: "clock").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("answer-later")
                    }
                }
                .controlSize(.large)
            }
        case .habit:
            HStack(spacing: 10) {
                Button { model.screen = .proof(ids) } label: {
                    Label("Prove it", systemImage: "checkmark.seal").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                Button { model.screen = .answers(.habit, ids) } label: {
                    Label("Not now", systemImage: "clock").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
        case .event:
            Button { Task { await model.answer(.event(ids[0], .gotItMainAlert)) } } label: {
                Label("Got it", systemImage: "hand.thumbsup").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }
}

// MARK: - Today

struct TodayStrip: View {
    @Environment(AppModel.self) private var model
    let open: (ItemKind, [UUID]) -> Void

    var body: some View {
        let today = model.today
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Today")
            if today.habits.isEmpty && today.reminders.isEmpty && today.events.isEmpty {
                Text("All clear").foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(chips(today), id: \.id) { chip in
                            ChipView(chip: chip, open: open)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.horizontal, -20)
            }
        }
        .accessibilityIdentifier("today-strip")
    }

    private func chips(_ t: TodaySummary) -> [Chip] {
        let cal = model.calendar
        var out: [(Date, Chip)] = []
        for h in t.habits {
            let start = h.day.at(h.habit.window.start, cal)
            let line: String
            switch h.phase {
            case .strict(let left): line = "\(h.week) of \(h.weekOf) · \(left) days to lock in"
            case .restrict(_, let left): line = "\(h.week) of \(h.weekOf) · strict \(left) more days"
            case .quiet: line = "\(h.week) of \(h.weekOf) this week"
            }
            let state: Chip.State
            switch h.outcome {
            case .done: state = .done
            case .missed: state = .missed
            case .excused: state = .excused
            case .pending: state = h.isCheckbox ? .checkbox : .pending
            }
            out.append((start, Chip(id: h.habit.id, kind: .habit, title: h.habit.name,
                                    time: Formats.time(h.habit.window.start, calendar: cal), line: line,
                                    state: state, important: h.important)))
        }
        for r in t.reminders {
            let due = r.due ?? model.now
            out.append((due, Chip(id: r.id, kind: .reminder, title: r.title, time: Formats.time(due, calendar: cal),
                                  line: due <= model.now ? "Waiting for an answer" : nil,
                                  state: due <= model.now ? .ringing : .pending, important: false)))
        }
        for e in t.events {
            out.append((e.start, Chip(id: e.id, kind: .event, title: e.title, time: Formats.time(e.start, calendar: cal),
                                      line: e.end.map { "until \(Formats.time($0, calendar: cal))" },
                                      state: e.start <= model.now ? .done : .pending, important: false)))
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

struct Chip: Hashable {
    enum State { case pending, ringing, checkbox, done, missed, excused }
    var id: UUID
    var kind: ItemKind
    var title: String
    var time: String
    var line: String?
    var state: State
    var important: Bool
}

struct ChipView: View {
    @Environment(AppModel.self) private var model
    let chip: Chip
    let open: (ItemKind, [UUID]) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if chip.state == .checkbox {
                Button { Task { await model.answer(.habit(chip.id, .check)) } } label: {
                    Image(systemName: "square").font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tick \(chip.title)")
            } else {
                Image(systemName: icon).font(.title3).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(chip.time).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(chip.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let line = chip.line {
                    Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minWidth: 130, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .overlay {
            if chip.important {
                RoundedRectangle(cornerRadius: 16).strokeBorder(Color.orange, lineWidth: 2)
            }
        }
        .contentShape(.rect(cornerRadius: 16))
        .onTapGesture { open(chip.kind, [chip.id]) }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch chip.state {
        case .done: return "checkmark.circle.fill"
        case .missed: return "xmark.circle"
        case .excused: return "minus.circle"
        case .ringing: return "bell.fill"
        case .pending, .checkbox:
            switch chip.kind {
            case .habit: return "repeat"
            case .reminder: return "bell"
            case .event: return "calendar"
            }
        }
    }

    private var tint: Color {
        switch chip.state {
        case .done: return .green
        case .missed: return .red
        case .ringing: return .orange
        default: return .accentColor
        }
    }
}

// MARK: - Upcoming

struct UpcomingList: View {
    @Environment(AppModel.self) private var model
    let open: (UUID) -> Void

    var body: some View {
        let events = model.upcoming
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Upcoming")
            if events.isEmpty {
                Text("No events coming up").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(events.prefix(20).enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Divider().padding(.leading, 16) }
                        Button { open(e.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.title).font(.body.weight(.medium))
                                    Text(Formats.when(e.start, now: model.now, calendar: model.calendar))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Formats.dayDistance(e.start, now: model.now, calendar: model.calendar))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
            }
        }
        .accessibilityIdentifier("upcoming")
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}
