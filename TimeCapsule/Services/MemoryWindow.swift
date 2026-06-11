import Foundation

/// Single source of truth for how many days around today's date count as
/// "this day" when looking back at past years. Both the gallery fetch
/// (`PhotoLibraryModel.fetchOnThisDay()`) and the notification count
/// (`MemoryLibrary.count(on:)`) must use this so the two
/// surfaces never disagree.
enum MemoryWindow {
    static let storageKey = "TimeCapsule.memoryDayWindow"
    static let lookbackYears = 20
    static let defaultDayWindow = 0

    /// 0 = exact day only. Clamped so a corrupt default can't explode fetches.
    static var dayWindow: Int {
        max(0, min(UserDefaults.standard.object(forKey: storageKey) as? Int ?? defaultDayWindow, 7))
    }

    /// Date range for the anniversary of `referenceDate` in `anniversaryYear`,
    /// widened by the configured window on both sides. `end` is exclusive.
    static func range(
        for referenceDate: Date,
        anniversaryYear: Int,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date)? {
        let month = calendar.component(.month, from: referenceDate)
        let day = calendar.component(.day, from: referenceDate)
        guard let anniversary = calendar.date(from: DateComponents(year: anniversaryYear, month: month, day: day)) else {
            return nil
        }
        let window = dayWindow
        guard let start = calendar.date(byAdding: .day, value: -window, to: anniversary),
              let end = calendar.date(byAdding: .day, value: window + 1, to: anniversary) else {
            return nil
        }
        return (start, end)
    }
}
