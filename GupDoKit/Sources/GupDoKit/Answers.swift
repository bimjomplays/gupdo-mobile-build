import Foundation

// One way in for every answer, wherever it was given (a notification button, an alarm button, the Now card, the
// Today strip): the app turns the button into an `AppAnswer` (or a screen to show, for answers that need a choice
// first), applies it to the saved data here, saves, and replans. Replanning drops the answered item's pending
// notifications and alarms, which is what "answering anywhere stops the escalation" means.

/// An answer to one item.
enum AppAnswer: Codable, Hashable {
    case reminder(UUID, ReminderAnswer)
    /// Goes to the habit-day that is open now (`HabitLogic.openDay`).
    case habit(UUID, HabitAnswer)
    case event(UUID, EventAnswer)

    var itemID: UUID {
        switch self {
        case .reminder(let id, _), .habit(let id, _), .event(let id, _): return id
        }
    }
}

enum AnswerError: Error, Equatable {
    case unknownItem
}

enum Answers {
    /// Applies `answer` and returns the data to save. Throws the rule's error when the answer isn't allowed now.
    static func apply(_ answer: AppAnswer, to data: GupDoData, context: PhoneContext = PhoneContext(), now: Date,
                      calendar: Calendar) throws -> GupDoData {
        var data = data
        switch answer {
        case .reminder(let id, let a):
            guard let i = data.reminders.firstIndex(where: { $0.id == id }) else { throw AnswerError.unknownItem }
            data.reminders[i] = try ReminderLogic.answer(a, to: data.reminders[i], now: now, settings: data.settings,
                                                         calendar: calendar)
        case .habit(let id, let a):
            guard let h = data.habits.first(where: { $0.id == id }) else { throw AnswerError.unknownItem }
            let day = HabitLogic.openDay(h, now: now, calendar: calendar)
            let phase = HabitLogic.phase(h, on: day, history: data.history, now: now, calendar: calendar)
            data.history[h.id, day] = try HabitLogic.answer(a, habit: h, log: data.history[h.id, day], phase: phase,
                                                            context: context, now: now, calendar: calendar)
        case .event(let id, let a):
            guard let i = data.events.firstIndex(where: { $0.id == id }) else { throw AnswerError.unknownItem }
            data.events[i] = EventLogic.answer(a, to: data.events[i], now: now)
        }
        return data
    }

    /// Applies each answer that is allowed (a group habit alarm answers every habit in it); returns the data and how
    /// many were applied.
    static func applyAll(_ answers: [AppAnswer], to data: GupDoData, context: PhoneContext = PhoneContext(),
                         now: Date, calendar: Calendar) -> (data: GupDoData, applied: Int) {
        var data = data, applied = 0
        for a in answers {
            if let next = try? apply(a, to: data, context: context, now: now, calendar: calendar) {
                data = next
                applied += 1
            }
        }
        return (data, applied)
    }

    /// The habit choices for the day open now (Done, 15 min if unused, Can't right now when driving or away).
    static func habitChoices(_ h: Habit, data: GupDoData, context: PhoneContext, now: Date,
                             calendar: Calendar) -> [HabitChoice] {
        let day = HabitLogic.openDay(h, now: now, calendar: calendar)
        let phase = HabitLogic.phase(h, on: day, history: data.history, now: now, calendar: calendar)
        return HabitLogic.choices(h, log: data.history[h.id, day], phase: phase, context: context)
    }

    /// Is the habit already proved for the day open now?
    static func isProved(_ h: Habit, data: GupDoData, now: Date, calendar: Calendar) -> Bool {
        let day = HabitLogic.openDay(h, now: now, calendar: calendar)
        return data.history.log(h.id, day)?.provedAt != nil
    }
}
