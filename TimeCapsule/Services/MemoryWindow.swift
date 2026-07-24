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
    static func logicalDate(for date: Date, calendar: Calendar = .current) -> Date {
        let startHour = dayStartHour
        guard startHour > 0 else { return date }
        let hour = calendar.component(.hour, from: date)
        guard hour < startHour else { return date }
        return calendar.date(byAdding: .day, value: -1, to: date) ?? date
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
