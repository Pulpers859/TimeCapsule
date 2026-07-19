import Photos
import UserNotifications

@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    private let legacyDailyID = "timecapsule.daily"
    private let dailyPrefix = "timecapsule.daily."
    private let daysToSchedule = 60
    private let preferences = UserDefaults.standard
    private var schedulingTask: Task<Void, Never>?
    private var generation = 0

    private override init() {
        UserDefaults.standard.register(defaults: NotificationPreferences.defaults)
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePhotoLibraryChange),
            name: .timeCapsulePhotosDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePhotoLibraryChange),
            name: .timeCapsulePhotoAuthorizationDidChange,
            object: nil
        )
    }

    var notificationsEnabled: Bool {
        get { preferences.bool(forKey: NotificationPreferences.notificationsEnabledKey) }
        set { preferences.set(newValue, forKey: NotificationPreferences.notificationsEnabledKey) }
    }

    var notificationHour: Int {
        get { preferences.integer(forKey: NotificationPreferences.notificationHourKey) }
        set { preferences.set(newValue, forKey: NotificationPreferences.notificationHourKey) }
    }

    var notificationMinute: Int {
        get { preferences.integer(forKey: NotificationPreferences.notificationMinuteKey) }
        set { preferences.set(newValue, forKey: NotificationPreferences.notificationMinuteKey) }
    }

    func requestAndSchedule() {
        guard notificationsEnabled else {
            cancelAndRemoveScheduledNotifications()
            return
        }
        replaceSchedulingTask(requestAuthorization: true)
    }

    func refreshScheduleIfNeeded(force: Bool = false) {
        guard notificationsEnabled else {
            cancelAndRemoveScheduledNotifications()
            return
        }

        let lastRefresh = preferences.object(forKey: NotificationPreferences.lastNotificationRefreshKey) as? Date
        guard force || lastRefresh.map({ !Calendar.current.isDateInToday($0) }) ?? true else { return }
        replaceSchedulingTask(requestAuthorization: false)
    }

    func updatePreferences(enabled: Bool, notifyAt date: Date) {
        notificationsEnabled = enabled
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        notificationHour = components.hour ?? NotificationPreferences.defaultNotificationHour
        notificationMinute = components.minute ?? NotificationPreferences.defaultNotificationMinute

        if enabled {
            requestAndSchedule()
        } else {
            cancelAndRemoveScheduledNotifications()
        }
    }

    func removeScheduledNotifications() {
        cancelAndRemoveScheduledNotifications()
    }

    private func replaceSchedulingTask(requestAuthorization: Bool) {
        generation += 1
        let requestedGeneration = generation
        schedulingTask?.cancel()
        schedulingTask = Task { [weak self] in
            guard let self else { return }
            await self.schedule(requestAuthorization: requestAuthorization, generation: requestedGeneration)
        }
    }

    private func schedule(requestAuthorization: Bool, generation requestedGeneration: Int) async {
        guard isCurrent(requestedGeneration) else { return }
        let center = UNUserNotificationCenter.current()

        if requestAuthorization {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard isCurrent(requestedGeneration) else { return }
            if !granted {
                notificationsEnabled = false
                cancelAndRemoveScheduledNotifications()
                return
            }
        } else {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                notificationsEnabled = false
                cancelAndRemoveScheduledNotifications()
                return
            }
        }

        let calendar = Calendar.current
        let slots = NotificationPlan.slots(
            now: Date(),
            calendar: calendar,
            hour: notificationHour,
            minute: notificationMinute,
            count: daysToSchedule,
            identifierPrefix: dailyPrefix
        )
        let canAccessPhotos = {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            return status == .authorized || status == .limited
        }()
        let dayWindow = MemoryWindow.dayWindow
        let countTask = Task.detached(priority: .utility) { () -> [(NotificationSlot, Int)]? in
            var requests: [(NotificationSlot, Int)] = []
            for slot in slots {
                guard !Task.isCancelled else { return nil }
                requests.append((
                    slot,
                    canAccessPhotos ? MemoryLibrary.count(on: slot.targetDate, calendar: calendar) : 0
                ))
            }
            return requests
        }
        let plannedRequests = await withTaskCancellationHandler {
            await countTask.value
        } onCancel: {
            countTask.cancel()
        }

        guard let plannedRequests, isCurrent(requestedGeneration) else { return }
        let pending = await center.pendingNotificationRequests()
        let oldIDs = ownedIdentifiers(in: pending.map(\.identifier))

        do {
            for (slot, count) in plannedRequests {
                guard isCurrent(requestedGeneration) else { throw CancellationError() }
                let content = UNMutableNotificationContent()
                content.title = "Time Capsule"
                content.body = NotificationPlan.body(memoryCount: count, dayWindow: dayWindow)
                content.sound = .default
                let components = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: slot.fireDate
                )
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                try await center.add(UNNotificationRequest(identifier: slot.identifier, content: content, trigger: trigger))
            }

            guard isCurrent(requestedGeneration) else { throw CancellationError() }
            let newIDs = Set(plannedRequests.map { $0.0.identifier })
            let staleIDs = oldIDs.filter { !newIDs.contains($0) }
            if !staleIDs.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: staleIDs)
            }
            preferences.set(Date(), forKey: NotificationPreferences.lastNotificationRefreshKey)
            schedulingTask = nil
        } catch {}
    }

    private func cancelAndRemoveScheduledNotifications() {
        generation += 1
        let removalGeneration = generation
        schedulingTask?.cancel()
        schedulingTask = nil
        let legacyDailyID = legacyDailyID
        let dailyPrefix = dailyPrefix
        Task {
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            guard removalGeneration == generation, !notificationsEnabled else { return }
            let ids = pending.map(\.identifier).filter {
                $0 == legacyDailyID || $0.hasPrefix(dailyPrefix)
            }
            if !ids.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    private func ownedIdentifiers(in identifiers: [String]) -> [String] {
        identifiers.filter { $0 == legacyDailyID || $0.hasPrefix(dailyPrefix) }
    }

    private func isCurrent(_ requestedGeneration: Int) -> Bool {
        !Task.isCancelled && requestedGeneration == generation && notificationsEnabled
    }

    @objc private func handlePhotoLibraryChange() {
        refreshScheduleIfNeeded(force: true)
    }
}
