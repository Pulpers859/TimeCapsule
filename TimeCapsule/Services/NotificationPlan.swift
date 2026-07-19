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

    public static func body(memoryCount: Int, dayWindow: Int) -> String {
        let dayPhrase = dayWindow > 0 ? "around this day" : "this day"
        switch memoryCount {
        case 1:
            return "You have 1 memory from \(dayPhrase) in a past year."
        case 2...:
            return "You have \(memoryCount) memories from \(dayPhrase) in past years."
        default:
            return "Check today's memories from \(dayPhrase) in past years."
        }
    }
}
