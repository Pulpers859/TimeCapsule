import Foundation

enum NotificationPreferences {
    static let notificationsEnabledKey = "TimeCapsule.notificationsEnabled"
    static let notificationHourKey = "TimeCapsule.notificationHour"
    static let notificationMinuteKey = "TimeCapsule.notificationMinute"
    static let lastNotificationRefreshKey = "TimeCapsule.lastNotificationRefresh"

    static let defaultNotificationsEnabled = true
    static let defaultNotificationHour = 9
    static let defaultNotificationMinute = 0

    static let defaults: [String: Any] = [
        notificationsEnabledKey: defaultNotificationsEnabled,
        notificationHourKey: defaultNotificationHour,
        notificationMinuteKey: defaultNotificationMinute
    ]

    static func reminderDate(hour: Int, minute: Int, calendar: Calendar = .current, now: Date = Date()) -> Date {
        calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: now
        ) ?? now
    }
}
