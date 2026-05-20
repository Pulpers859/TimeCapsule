import UserNotifications
import Photos

class NotificationManager: NSObject {

    static let shared = NotificationManager()
    private init() {
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

    private enum Keys {
        static let notificationsEnabled = "TimeCapsule.notificationsEnabled"
        static let notificationHour = "TimeCapsule.notificationHour"
        static let notificationMinute = "TimeCapsule.notificationMinute"
        static let lastNotificationRefresh = "TimeCapsule.lastNotificationRefresh"
    }

    var notificationsEnabled: Bool {
        get {
            if preferences.object(forKey: Keys.notificationsEnabled) == nil {
                return true
            }
            return preferences.bool(forKey: Keys.notificationsEnabled)
        }
        set {
            preferences.set(newValue, forKey: Keys.notificationsEnabled)
        }
    }

    var notificationHour: Int {
        get {
            if preferences.object(forKey: Keys.notificationHour) == nil {
                return 9
            }
            return preferences.integer(forKey: Keys.notificationHour)
        }
        set {
            preferences.set(newValue, forKey: Keys.notificationHour)
        }
    }

    var notificationMinute: Int {
        get {
            if preferences.object(forKey: Keys.notificationMinute) == nil {
                return 0
            }
            return preferences.integer(forKey: Keys.notificationMinute)
        }
        set {
            preferences.set(newValue, forKey: Keys.notificationMinute)
        }
    }

    // Call once on launch to request permission and schedule
    func requestAndSchedule() {
        guard notificationsEnabled else {
            removeScheduledNotifications()
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                self.scheduleDailyNotification()
            }
        }
    }

    func refreshScheduleIfNeeded(force: Bool = false) {
        guard notificationsEnabled else {
            removeScheduledNotifications()
            return
        }

        let lastRefresh = preferences.object(forKey: Keys.lastNotificationRefresh) as? Date
        let shouldRefresh = force || lastRefresh == nil || Calendar.current.isDateInToday(lastRefresh!) == false

        if shouldRefresh {
            scheduleDailyNotification()
        }
    }

    func updatePreferences(enabled: Bool, notifyAt date: Date) {
        notificationsEnabled = enabled

        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        notificationHour = components.hour ?? 9
        notificationMinute = components.minute ?? 0

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
                let count = self.countMemories(on: targetDate)

                let content = UNMutableNotificationContent()
                content.title = "Time Capsule 📸"
                if count == 1 {
                    content.body = "You have 1 memory from this day in a past year."
                } else if count > 1 {
                    content.body = "You have \(count) memories from this day in past years."
                } else {
                    content.body = "Check today's memories from this day in past years."
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

            self.preferences.set(Date(), forKey: Keys.lastNotificationRefresh)
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

    private func countMemories(on date: Date) -> Int {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            return 0
        }

        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)

        var total = 0

        for year in stride(from: currentYear - 1, through: currentYear - 20, by: -1) {
            guard let startDate = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  let endDate = calendar.date(byAdding: .day, value: 1, to: startDate) else { continue }

            let opts = PHFetchOptions()
            opts.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@",
                startDate as NSDate,
                endDate as NSDate
            )
            let result = PHAsset.fetchAssets(with: opts)
            result.enumerateObjects { asset, _, _ in
                if asset.mediaType == .image || asset.mediaType == .video {
                    total += 1
                }
            }
        }

        return total
    }

    @objc private func handlePhotoLibraryChange() {
        refreshScheduleIfNeeded(force: true)
    }
}
