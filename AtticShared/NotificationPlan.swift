import Foundation

nonisolated public struct NotificationSlot: Equatable, Sendable {
    public let identifier: String
    public let targetDate: Date
    public let fireDate: Date

    public init(identifier: String, targetDate: Date, fireDate: Date) {
        self.identifier = identifier
        self.targetDate = targetDate
        self.fireDate = fireDate
    }
}

nonisolated public enum NotificationPlan {
    public static func slots(
        now: Date,
        calendar: Calendar,
        hour: Int,
        minute: Int,
        count: Int,
        identifierPrefix: String
    ) -> [NotificationSlot] {
        guard count > 0 else { return [] }

        let startOfToday = calendar.startOfDay(for: now)
        var result: [NotificationSlot] = []
        var offset = 0

        while result.count < count && offset < count + 2 {
            defer { offset += 1 }
            guard let targetDate = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                  let fireDate = calendar.date(
                    bySettingHour: hour,
                    minute: minute,
                    second: 0,
                    of: targetDate
                  ),
                  fireDate > now else {
                continue
            }

            let components = calendar.dateComponents([.year, .month, .day], from: targetDate)
            let identifier = String(
                format: "%@%04d%02d%02d",
                identifierPrefix,
                components.year ?? 0,
                components.month ?? 0,
                components.day ?? 0
            )
            result.append(NotificationSlot(identifier: identifier, targetDate: targetDate, fireDate: fireDate))
        }

        return result
    }

    /// - Parameter lookbackYears: how many past years the count covered, or
    ///   nil for the full history — which is what every existing caller meant
    ///   before the free version was limited.
    ///
    ///   Optional rather than defaulting to `MemoryWindow.fullLookbackYears`
    ///   because this function is `public` and `MemoryWindow` is not: a public
    ///   function's default argument may only reference public declarations.
    public static func body(
        memoryCount: Int,
        dayWindow: Int,
        lookbackYears: Int? = nil
    ) -> String {
        let dayPhrase = dayWindow > 0 ? "around this day" : "this day"
        let searchedYears = lookbackYears ?? MemoryWindow.fullLookbackYears
        switch memoryCount {
        case 1:
            return "You have 1 memory from \(dayPhrase) in a past year."
        case 2...:
            return "You have \(memoryCount) memories from \(dayPhrase) in past years."
        default:
            // Says there is nothing, instead of promising something.
            //
            // This branch used to read "Check today's memories from this day
            // in past years" on a day holding none, so the reminder made a
            // claim the app then contradicted the moment it opened. A
            // reminder on a quiet day is wanted; a reminder that is wrong is
            // not.
            //
            // And it says *which* years. The free version only searches the
            // recent ones, and "nothing from this day in past years" is false
            // for someone whose 2016 is full of photos they cannot see yet.
            if searchedYears < MemoryWindow.fullLookbackYears {
                return "Nothing from \(dayPhrase) in the last \(searchedYears) years. Today could be next year's."
            }
            return "Nothing from \(dayPhrase) in past years. Today could be next year's."
        }
    }
}
