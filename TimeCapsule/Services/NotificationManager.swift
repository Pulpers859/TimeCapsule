import Photos
import UserNotifications

class NotificationManager: NSObject {

    static let shared = NotificationManager()
    private override init() {
        UserDefaults.standard.register(defaults: NotificationPreferences.defaults)
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePhotoLibraryChange),
            name: .timeCapsulePhotosDidChange,
            object: nil
        )
    }
    private let legacyDailyID = "timecapsule.daily"
    private let dailyPrefix = "timecapsule.daily."
    private let daysToSchedule = 60
    private let preferences = UserDefaults.standard
    private var canAccessPhotoLibrary: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    var notificationsEnabled: Bool {
        get {
            preferences.bool(forKey: NotificationPreferences.notificationsEnabledKey)
        }
        set {
            preferences.set(newValue, forKey: NotificationPreferences.notificationsEnabledKey)
        }
    }

    var notificationHour: Int {
        get {
            preferences.integer(forKey: NotificationPreferences.notificationHourKey)
        }
        set {
            preferences.set(newValue, forKey: NotificationPreferences.notificationHourKey)
        }
    }

    var notificationMinute: Int {
        get {
            preferences.integer(forKey: NotificationPreferences.notificationMinuteKey)
        }
        set {
            preferences.set(newValue, forKey: NotificationPreferences.notificationMinuteKey)
        }
    }

    // Called on launch for existing opt-in users and from Settings when enabled.
    func requestAndSchedule() {
        guard notificationsEnabled else {
            removeScheduledNotifications()
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                self.scheduleDailyNotification()
            } else {
                self.notificationsEnabled = false
                self.removeScheduledNotifications()
            }
        }
    }

    func refreshScheduleIfNeeded(force: Bool = false) {
        guard notificationsEnabled else {
            removeScheduledNotifications()
            return
        }

        let lastRefresh = preferences.object(forKey: NotificationPreferences.lastNotificationRefreshKey) as? Date
        let shouldRefresh = force || lastRefresh == nil || Calendar.current.isDateInToday(lastRefresh!) == false

        if shouldRefresh {
            scheduleDailyNotification()
        }
    }

    func updatePreferences(enabled: Bool, notifyAt date: Date) {
        notificationsEnabled = enabled

        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        notificationHour = components.hour ?? NotificationPreferences.defaultNotificationHour
        notificationMinute = components.minute ?? NotificationPreferences.defaultNotificationMinute

        if enabled {
            requestAndSchedule()
        } else {
            removeScheduledNotifications()
        }
    }

    func scheduleDailyNotification() {
        let center = UNUserNotificationCenter.current()

        center.getPendingNotificationRequests { requests in
            let idsToRemove = requests
                .map(\.identifier)
                .filter { $0 == self.legacyDailyID || $0.hasPrefix(self.dailyPrefix) }
            if !idsToRemove.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: idsToRemove)
            }

            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: Date())

            // iOS allows up to 64 pending local notifications.
            // Keep a rolling 60-day window and refresh whenever the app becomes active.
            for dayOffset in 0..<self.daysToSchedule {
                guard let targetDate = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else { continue }
                let count = self.canAccessPhotoLibrary ? MemoryLibrary.count(on: targetDate) : 0

                let content = UNMutableNotificationContent()
                content.title = "Time Capsule 📸"
                let dayPhrase = MemoryWindow.dayWindow > 0 ? "around this day" : "this day"
                if count == 1 {
                    content.body = "You have 1 memory from \(dayPhrase) in a past year."
                } else if count > 1 {
                    content.body = "You have \(count) memories from \(dayPhrase) in past years."
                } else {
                    content.body = "Check today's memories from \(dayPhrase) in past years."
                }
                content.sound = .default

                let fireDate = calendar.date(
                    bySettingHour: self.notificationHour,
                    minute: self.notificationMinute,
                    second: 0,
                    of: targetDate
                ) ?? targetDate
                let triggerComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd"
                let identifier = "\(self.dailyPrefix)\(formatter.string(from: targetDate))"
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

                center.add(request)
            }

            self.preferences.set(Date(), forKey: NotificationPreferences.lastNotificationRefreshKey)
        }
    }

    func removeScheduledNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let idsToRemove = requests
                .map(\.identifier)
                .filter { $0 == self.legacyDailyID || $0.hasPrefix(self.dailyPrefix) }
            if !idsToRemove.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: idsToRemove)
            }
        }
    }

    @objc private func handlePhotoLibraryChange() {
        refreshScheduleIfNeeded(force: true)
    }
}
