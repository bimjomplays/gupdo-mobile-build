# GupDoKit

GupDo's plain logic: models, the reminder/habit/event rules from the App plan, and the alert planner. No SwiftUI or
UIKit; the app compiles `Sources/GupDoKit` directly (nothing is `public`).

```sh
swift test --package-path GupDoKit
```

## How the app uses it

1. Keep everything in one `GupDoData` (Codable; `encoded()` / `GupDoData.decode`) in a local JSON file.
2. Answers go through the logic, which returns the updated value to save:
   - `ReminderLogic.answer(_:to:now:settings:calendar:)`, `ReminderLogic.choices(for:)`, `laterChoices(now:...)`
   - `HabitLogic.answer(_:habit:log:phase:context:now:calendar:)`, `HabitLogic.choices(...)`;
     the day's log is `data.history[habit.id, DayKey(now, calendar)]`, the phase `HabitLogic.phase(...)`.
   - `EventLogic.answer(_:to:now:)`
3. Phone signals: region monitoring's enter/leave of a saved place -> `Presence.entered` / `Presence.left` (kept as
   `data.visits`; `Presence.settle` writes them into place habits' day logs on every refresh, so a phone that sat at
   home all day still counts as there). A new visit also starts the arrival reminders waiting for that place
   (`ReminderLogic.arrived`: Time Sensitive 30 s later, then alarms). Which places to watch: `PlaceWatch.pick` (needed
   ones first, at most 19 of iOS's 20); what blocks deleting one: `PlaceUse.users`.
   Time to leave: an event's Where (`Event.location`, a copy of a saved place or a searched address) gets a MapKit
   drive time on save; `TravelTime.due` says which to ask again whenever the app runs, `TravelTime.update` picks the
   alarm (drive + 10 min buffer; a fresh drive time moves it either way, one older than 2 h only earlier; unknown =
   1 hour before), `TravelTime.nextCheck` times the background refresh.
   Driving: `Driving.isDriving` from Core Motion samples (+ GPS speed); `DrivingPauses.end` when it stops.
   Proof: `PhotoMatch.verdict(distance:)` (Vision feature-print distance, threshold tuned on the CI Mac with
   ios/ci/photo-match), `ProofCheck.byLocation` / `byTag` for a group's checklist.
4. After every answer, launch and background wake: `Planner.plan(data, now:, presence:, calendar:)`, then remove
   everything scheduled before and schedule `plan.alerts` (`plain`/`timeSensitive` -> UNUserNotificationCenter
   with the `category`'s buttons, `alarm` -> AlarmKit). Pass `presence: Presence.inside(data)`. The app watches
   every saved place (not only `plan.regions`) so the visits stay true.
5. Main screen: `TodayLogic.nowCard`, `TodayLogic.today`, `EventLogic.upcoming`; clash warning on save:
   `EventLogic.clashes(for:among:)`; setup checks: `Setup.problems(...)`.

## Rules decided beyond the plan (main chat, 2026-11-15)

- Can't right now is a pause, not a pass: alarms stop while away from the place (place habits) or driving; it fires
  again on arrival (+3 min) or when driving stops, if the window is still open. Still away at window end -> excused.
  Anywhere habits: only while driving.
- Back to Strict after 2 Quiet misses in any 7-day span = 14 calendar days, then Quiet.
- Later: Tonight = 8pm (setting; hidden within 15 min of it), Tomorrow = same clock time tomorrow; Pick a day (after
  the 3rd Later) keeps the clock time and starts the Later count over.
- One ringing cycle schedules 12 alarms (1 hour) for reminders and events; habits ring until the window ends.
- Time to leave without a known travel time: 1 hour before. With one: drive time + 10 minutes (setting); background
  refresh is never relied on, the alarm is scheduled at save and only refined. An event without an end is an instant for clashes.
- A habit window whose end is at or before its start (10pm-1am) ends the next day; the habit-day (log, scheduled
  day, Today strip until it closes) is the start day. `HabitLogic.openDay` says which day answers go to.
