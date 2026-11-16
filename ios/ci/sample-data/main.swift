// Writes a GupDo data file full of placeholder examples, for the CI launch check (ios/ci/launch-check.sh): the app is
// launched once on a fresh install and once with this file in its Application Support, so the launch path runs with
// something to plan (a habit ringing now, an arrival reminder, an event with a Where and time to leave). Built on the
// CI's Mac together with GupDoKit's sources:
//   swiftc -swift-version 5 ../GupDoKit/Sources/GupDoKit/*.swift ci/sample-data/main.swift -o sample-data
//   ./sample-data gupdo.json
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else { print("usage: sample-data OUT.json"); exit(2) }

let now = Date()
let cal = Calendar.current
var data = Samples.data(now: now, calendar: cal)
let today = DayKey(now, cal)
let hour = cal.component(.hour, from: now)
let place = Place(name: "Shop (example)", latitude: 37.3349, longitude: -122.009, radius: 150)
data.places.append(place)
// a habit whose window is now (it rings: Now card, alerts, an alarm), at a place, location proof
data.habits.append(Habit(name: "Example habit now",
                         window: TimeWindow(start: TimeOfDay(hour), end: TimeOfDay(min(hour + 1, 23), 59)),
                         placeID: place.id, proof: .location, startDay: today))
// "when I arrive" reminder (region monitoring) and one due in a few minutes
data.reminders.append(Reminder(title: "Example arrival reminder", trigger: .arrival(placeID: place.id), createdAt: now))
data.reminders.append(Reminder(title: "Example reminder soon", trigger: .time(now.addingTimeInterval(5 * 60)),
                               createdAt: now))
// an event in two hours with a Where: time to leave asks MapKit for the drive time
data.events.append(Event(title: "Example event with a place", start: now.addingTimeInterval(2 * 3600),
                         end: now.addingTimeInterval(3 * 3600), location: EventLocation(place: place)))
try data.encoded().write(to: URL(fileURLWithPath: args[1]))
print("sample data: \(data.places.count) places, \(data.reminders.count) reminders, \(data.habits.count) habits, "
      + "\(data.events.count) events -> \(args[1])")
