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
3. Phone signals: arrival at a watched place -> `ReminderLogic.arrived` and `HabitLogic.arrived`; driving stopped
   -> `HabitLogic.stoppedDriving`.
4. After every answer, launch and background wake: `Planner.plan(data, now:, presence:, calendar:)`, then remove
   everything scheduled before and schedule `plan.alerts` (`plain`/`timeSensitive` -> UNUserNotificationCenter
   with the `category`'s buttons, `alarm` -> AlarmKit) and monitor `plan.regions`.
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
- Time to leave without a known travel time: 1 hour before. An event without an end is an instant for clashes.
- A habit window whose end is at or before its start (10pm-1am) ends the next day; the habit-day (log, scheduled
  day, Today strip until it closes) is the start day. `HabitLogic.openDay` says which day answers go to.
