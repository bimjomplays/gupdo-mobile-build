import Foundation

// Placeholder examples only (the owner enters their own habits). Used for a first launch's empty-state demo and in
// previews/tests; every name says it is an example.

enum Samples {
    static func data(now: Date, calendar: Calendar) -> GupDoData {
        let home = Place(name: "Home (example)", latitude: 0, longitude: 0, isHome: true)
        let today = DayKey(now, calendar)
        var data = GupDoData()
        data.places = [home]
        data.reminders = [
            Reminder(title: "Example reminder", trigger: .time(today.adding(days: 1, calendar).at(TimeOfDay(10), calendar)),
                     createdAt: now),
        ]
        data.habits = [
            Habit(name: "Example habit", window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8)),
                  placeID: home.id, proof: .photo, referencePhoto: "example-reference.jpg", startDay: today),
            Habit(name: "Example habit 2", days: .weekdays([2, 3, 4, 5, 6]),
                  window: TimeWindow(start: TimeOfDay(21), end: TimeOfDay(22)), proof: .nfc,
                  nfcTagID: "example-tag", startDay: today),
        ]
        data.events = [
            Event(title: "Example event", start: today.adding(days: 6, calendar).at(TimeOfDay(14), calendar),
                  end: today.adding(days: 6, calendar).at(TimeOfDay(15), calendar)),
        ]
        return data
    }
}
