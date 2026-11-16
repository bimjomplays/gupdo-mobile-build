import Foundation

// The main screen's data: one Now card (what matters right now), the Today strip, the Upcoming list.

struct NowCard: Hashable {
    var itemKind: ItemKind
    var itemIDs: [UUID]
    var title: String
    /// Ringing now (due and unanswered) vs. the next thing coming today.
    var ringing: Bool
    var date: Date
}

struct TodayHabit: Hashable {
    var habit: Habit
    /// The habit-day shown (yesterday while last night's overnight window is still open).
    var day: DayKey
    var outcome: HabitOutcome
    var phase: HabitPhase
    /// Quiet habits show as a plain checkbox.
    var isCheckbox: Bool
    var important: Bool
    var week: Int
    var weekOf: Int
}

struct TodaySummary: Hashable {
    var habits: [TodayHabit]
    var reminders: [Reminder]
    var events: [Event]
}

enum TodayLogic {
    static func nowCard(_ data: GupDoData, now: Date, presence: Set<UUID> = [], calendar: Calendar) -> NowCard? {
        let s = data.settings
        let today = DayKey(now, calendar)
        let endOfToday = today.adding(days: 1, calendar).start(calendar)
        var ringing: [NowCard] = []
        var next: [NowCard] = []

        for r in data.reminders where r.status == .active {
            guard let due = r.due else { continue }
            let card = NowCard(itemKind: .reminder, itemIDs: [r.id], title: r.title, ringing: due <= now, date: due)
            if due <= now { ringing.append(card) } else if due < endOfToday { next.append(card) }
        }

        var groups: [String: NowCard] = [:]
        for day in [today.adding(days: -1, calendar), today] {
            for h in data.habits where HabitLogic.isScheduled(h, on: day, calendar: calendar) {
                let log = data.history.log(h.id, day)
                let end = HabitLogic.windowEnd(h, on: day, calendar: calendar)
                guard log?.provedAt == nil, end > now,
                      HabitLogic.phase(h, on: day, history: data.history, now: now, calendar: calendar).notifies,
                      let start = HabitLogic.cycleStart(h, on: day, log: log,
                                                        insideNow: h.placeID.map { presence.contains($0) } ?? false,
                                                        settings: s, calendar: calendar)
                else { continue }
                let key = "\(start.timeIntervalSince1970)|\(h.window.start.minutesSinceMidnight)|"
                    + "\(h.window.end.minutesSinceMidnight)|\(h.placeID?.uuidString ?? "")"
                if var card = groups[key] {
                    card.itemIDs.append(h.id)
                    card.title = "\(card.itemIDs.count) habits"
                    groups[key] = card
                } else {
                    groups[key] = NowCard(itemKind: .habit, itemIDs: [h.id], title: h.name, ringing: start <= now, date: start)
                }
            }
        }
        for card in groups.values { if card.ringing { ringing.append(card) } else { next.append(card) } }

        for e in data.events {
            let main = EventLogic.mainAlertDate(e, settings: s)
            if EventLogic.isRinging(e, now: now, settings: s) {
                ringing.append(NowCard(itemKind: .event, itemIDs: [e.id], title: e.title, ringing: true, date: main))
            } else if e.mainAlertAnsweredAt == nil, main > now, main < endOfToday {
                next.append(NowCard(itemKind: .event, itemIDs: [e.id], title: e.title, ringing: false, date: main))
            }
        }

        let order: (NowCard, NowCard) -> Bool = { ($0.date, $0.title) < ($1.date, $1.title) }
        return ringing.sorted(by: order).first ?? next.sorted(by: order).first
    }

    static func today(_ data: GupDoData, now: Date, calendar: Calendar) -> TodaySummary {
        let today = DayKey(now, calendar)
        let start = today.start(calendar), end = today.adding(days: 1, calendar).start(calendar)
        let habits: [TodayHabit] = data.habits.compactMap { h in
            let day = HabitLogic.openDay(h, now: now, calendar: calendar)
            guard let outcome = HabitLogic.outcome(h, on: day, log: data.history.log(h.id, day), now: now,
                                                   calendar: calendar) else { return nil }
            let phase = HabitLogic.phase(h, on: day, history: data.history, now: now, calendar: calendar)
            let week = HabitLogic.weekProgress(h, history: data.history, today: day, now: now, calendar: calendar)
            return TodayHabit(habit: h, day: day, outcome: outcome, phase: phase, isCheckbox: !phase.notifies,
                              important: HabitLogic.isImportantToday(h, history: data.history, today: day, now: now,
                                                                     calendar: calendar),
                              week: week.done, weekOf: week.of)
        }.sorted { ($0.habit.window.start, $0.habit.name) < ($1.habit.window.start, $1.habit.name) }
        let reminders = data.reminders.filter { r in
            guard r.status == .active, let due = r.due else { return false }
            return due < end
        }.sorted { ($0.due ?? start) < ($1.due ?? start) }
        let events = data.events.filter { $0.start >= start && $0.start < end }.sorted { $0.start < $1.start }
        return TodaySummary(habits: habits, reminders: reminders, events: events)
    }
}
