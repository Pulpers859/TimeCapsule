import Foundation

/// Single source of truth for how many days around today's date count as
/// "this day" when looking back at past years. Both the gallery fetch
/// (`PhotoLibraryModel.fetchOnThisDay()`) and the notification count
/// (`MemoryLibrary.count(on:)`) must use this so the two
/// surfaces never disagree.
nonisolated enum MemoryWindow {
    static let storageKey = "TimeCapsule.memoryDayWindow"
    static let dayStartHourKey = "TimeCapsule.dayStartHour"
    static let lookbackYears = 20
    static let defaultDayWindow = 0
    static let defaultDayStartHour = 0

    static func clampedDayWindow(_ value: Int) -> Int {
        max(0, min(value, 7))
    }

    /// 0 = exact day only. Clamped so a corrupt default can't explode fetches.
    static var dayWindow: Int {
        clampedDayWindow(
            UserDefaults.standard.object(forKey: storageKey) as? Int ?? defaultDayWindow
        )
    }

    /// Hour (0–6) at which a new TimeCapsule "day" begins. Photos taken before
    /// this hour are attributed to the previous calendar day, so an event that
    /// runs past midnight stays grouped under the evening it started.
    /// 0 = midnight (default, preserves prior behavior).
    static var dayStartHour: Int {
        max(0, min(UserDefaults.standard.object(forKey: dayStartHourKey) as? Int ?? defaultDayStartHour, 6))
    }

    /// Returns the "logical date" for a given wall-clock time.
    /// When the clock reads before `dayStartHour`, the user is still in the
    /// previous evening — shift the reference date back one day so the gallery
    /// shows that evening's memories rather than the new calendar day's (which
    /// hasn't really started yet). Returns `date` unchanged when `dayStartHour == 0`.
    static func logicalDate(
        for date: Date,
        dayStartHour: Int = MemoryWindow.dayStartHour,
        calendar: Calendar = .current
    ) -> Date {
        let startHour = max(0, min(dayStartHour, 6))
        guard startHour > 0 else { return date }
        let hour = calendar.component(.hour, from: date)
        guard hour < startHour else { return date }
        return calendar.date(byAdding: .day, value: -1, to: date) ?? date
    }

    /// How many years back a memory is, measured the way an "on this day" app
    /// means it: the difference between calendar years, not elapsed duration.
    ///
    /// This distinction is the whole point of the helper. `Calendar`'s
    /// `dateComponents([.year], from:to:)` answers "how many whole years have
    /// *passed*", so a photo taken at 4:59 PM on Aug 3 2024, viewed at 8:03 AM
    /// on Aug 3 2026, comes back as 1 — the second anniversary is still nine
    /// hours away. The gallery groups that same photo under 2024 and labels it
    /// "2 Years Ago", so any surface using elapsed duration silently disagrees
    /// with the grid it was opened from, and only when the current time of day
    /// happens to fall earlier than the capture time.
    ///
    /// Both dates go through `logicalDate` so the answer matches how
    /// `range(for:anniversaryYear:)` attributes assets to a year: a photo taken
    /// just after midnight on Jan 1 belongs to the previous evening, and so to
    /// the previous year, whenever `dayStartHour` is non-zero.
    static func yearsAgo(
        for date: Date,
        relativeTo reference: Date = Date(),
        dayStartHour: Int = MemoryWindow.dayStartHour,
        calendar: Calendar = .current
    ) -> Int {
        let referenceYear = calendar.component(
            .year,
            from: logicalDate(for: reference, dayStartHour: dayStartHour, calendar: calendar)
        )
        let memoryYear = calendar.component(
            .year,
            from: logicalDate(for: date, dayStartHour: dayStartHour, calendar: calendar)
        )
        return referenceYear - memoryYear
    }

    /// Date range for the anniversary of `referenceDate` in `anniversaryYear`,
    /// widened by the configured window on both sides. `end` is exclusive.
    /// The range begins at `dayStartHour` (not midnight) so photos taken in the
    /// early hours of the next calendar day are attributed to the previous evening.
    static func range(
        for referenceDate: Date,
        anniversaryYear: Int,
        dayWindow: Int = MemoryWindow.dayWindow,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date)? {
        let month = calendar.component(.month, from: referenceDate)
        let day = calendar.component(.day, from: referenceDate)
        let startHour = dayStartHour

        // Include hour so the window begins at dayStartHour, not midnight.
        // The month/day equality check still correctly rejects non-existent
        // dates (e.g. Feb 29 in non-leap years).
        guard let anniversary = calendar.date(from: DateComponents(
            year: anniversaryYear, month: month, day: day,
            hour: startHour, minute: 0, second: 0
        )),
              calendar.component(.month, from: anniversary) == month,
              calendar.component(.day, from: anniversary) == day else {
            return nil
        }

        let window = clampedDayWindow(dayWindow)
        guard let start = calendar.date(byAdding: .day, value: -window, to: anniversary),
              let end = calendar.date(byAdding: .day, value: window + 1, to: anniversary) else {
            return nil
        }
        return (start, end)
    }
}
