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
    private var coalescedRefreshTask: Task<Void, Never>?
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
                // Counted on the *logical* date this notification will fire
                // on, not its calendar date. `NotificationPlan` anchors slots
                // to midnight, while the gallery and the widget both resolve
                // "today" through `MemoryWindow.logicalDate`. With a 6am day
                // start and a 5am reminder the two disagreed by a full day:
                // the notification promised day D's memories and the app it
                // opened showed day D-1's. No effect at the default day start
                // of midnight, where `logicalDate` is the identity.
                let target = MemoryWindow.logicalDate(for: slot.fireDate, calendar: calendar)
                requests.append((
                    slot,
                    // Each day resolves its own exclusions. They used to be
                    // resolved once for the whole pass, because resolving
                    // them walked every excluded album in full; now that the
                    // album lookup is bounded by the day being counted, a
                    // per-day resolve is both cheaper than the old shared one
                    // and correct for the day in question.
                    canAccessPhotos ? MemoryLibrary.count(on: target, calendar: calendar) : 0
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
                content.title = "Attic"
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
        // `force: true` is right: a delete changes the counts, so the bodies of
        // the already-scheduled notifications are stale and the daily guard
        // must be bypassed. Doing it per notification was not.
        //
        // Deleting several memories in a row posts one of these each, and each
        // one cancelled the in-flight reschedule and restarted the 60-day pass
        // from zero -- so during a burst the schedule never actually landed,
        // and the work done up to that point was thrown away every time.
        // Coalescing runs it once, after the user stops.
        coalescedRefreshTask?.cancel()
        coalescedRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.refreshScheduleIfNeeded(force: true)
        }
    }
}
