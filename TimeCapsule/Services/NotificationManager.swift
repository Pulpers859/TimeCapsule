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

        // A pass already running is left alone unless the caller forces one.
        //
        // On a cold launch `init()` starts a pass, and the first `.active`
        // transition arrives long before it finishes. The daily guard below
        // cannot see it, because the timestamp it reads is only written when
        // a pass *completes* — so every launch cancelled its own scheduling
        // mid-flight and started again. A user who backgrounded within a few
        // seconds could lose both passes and keep stale notification bodies
        // indefinitely. A forced refresh still supersedes, because that means
        // the counts themselves have changed.
        if !force, schedulingTask != nil { return }

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
        // Released on every exit, not just the successful one.
        //
        // `refreshScheduleIfNeeded` now treats a non-nil task as "a pass is
        // running" and declines to start another, so a handle left installed
        // by an early return — unauthorized, cancelled, superseded — would
        // block every future unforced pass for the life of the process. Only
        // the generation that still owns the handle clears it, so a pass that
        // has already been replaced cannot clear its successor's.
        defer {
            if requestedGeneration == generation {
                schedulingTask = nil
            }
        }

        guard isCurrent(requestedGeneration) else { return }
        let center = UNUserNotificationCenter.current()

        if requestAuthorization {
            // The status is read *before* asking, because `!granted` on its
            // own does not mean the user declined anything.
            //
            // iOS prompts once. Every later `requestAuthorization` on an app
            // whose status is already `.denied` returns false immediately,
            // with no error and no prompt shown. Treating that as a decline
            // is what defeated the fix below on every cold launch: `init()`
            // calls `requestAndSchedule()` unconditionally, and that path
            // asks. So someone who turned reminders off in iOS Settings kept
            // the tolerant behaviour only until the app was next launched
            // from cold, at which point the flag was cleared and the sixty
            // pending requests removed after all — the exact end state the
            // tolerant branch exists to prevent, arrived at a few hours
            // later.
            //
            // `notificationsEnabled` defaults to false and is only ever set
            // by the user turning the toggle on, so reaching here at launch
            // already implies they were prompted once and granted. A genuine
            // first prompt only happens from `updatePreferences`, and only
            // while the status is `.notDetermined`, which is precisely what
            // this now checks.
            let existing = await center.notificationSettings()
            guard isCurrent(requestedGeneration) else { return }

            if existing.authorizationStatus == .notDetermined {
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                guard isCurrent(requestedGeneration) else { return }
                if !granted {
                    // A real decline, to a prompt the user actually saw.
                    // Recording it in the toggle is honest rather than
                    // destructive.
                    notificationsEnabled = false
                    cancelAndRemoveScheduledNotifications()
                    return
                }
            } else {
                guard existing.authorizationStatus == .authorized || existing.authorizationStatus == .provisional else {
                    // Same tolerance as the refresh path below, and for the
                    // same reason: this is a system condition the user can
                    // reverse from iOS Settings, not a preference of theirs.
                    // Settings shows its own banner while authorization is
                    // denied, which is where that gets explained.
                    return
                }
            }
        } else {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                // Deliberately leaves `notificationsEnabled` alone.
                //
                // That flag is the user's stated preference; this is a system
                // condition they can reverse at any moment from iOS Settings.
                // Clearing it meant revoking permission there silently turned
                // the in-app reminder off for good: re-granting permission
                // restored nothing, and the banner that would have explained
                // it had gone too, because authorization was no longer denied.
                // Settings simply looked normal with reminders quietly off.
                //
                // Nothing is removed either. Pending requests cannot be
                // delivered while unauthorized, and leaving them means
                // re-granting permission resumes reminders immediately rather
                // than waiting for the next scheduling pass.
                //
                // The branch above is different on purpose: there the user has
                // just been asked and has declined, so recording that in the
                // toggle is honest rather than destructive.
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
            // Nothing is promised when the library cannot be read at all.
            //
            // `notificationsEnabled` and photo authorization are independent
            // settings, so a user who granted photo access, turned reminders
            // on, and later revoked photo access in iOS Settings kept getting
            // a daily "Check today's memories from this day in past years"
            // from an app that could no longer see a single photo — and
            // tapping it opened the permission screen. Every count was 0 and
            // the zero case falls through to that same generic body, so the
            // notification was indistinguishable from a real one.
            //
            // Returning an empty plan withdraws the promises rather than
            // rewording them: the sixty planned identifiers become the stale
            // set below and are removed. The preference itself is left alone,
            // because it is still what the user asked for, and re-granting
            // access reschedules through
            // `.timeCapsulePhotoAuthorizationDidChange`, which this class
            // already observes.
            //
            // This is deliberately only about having no access. Whether a day
            // with genuinely zero memories should still send a nudge is a
            // product question and is left as it is.
            guard canAccessPhotos else { return [] }

            // Resolved once for the whole pass, not per day.
            //
            // Album membership does not vary by date, so 60 resolutions can
            // only ever repeat work. A per-day resolve was briefly defensible
            // when every album lookup was bounded by the day being counted —
            // but cloud shared albums must now be fetched unbounded, because
            // PhotoKit raises an uncatchable exception on a predicate inside
            // one. Sixty unbounded walks of a five-thousand-photo shared
            // album per reschedule is the same scan storm this method was
            // rewritten to remove, on the album type people most want to
            // exclude, triggered by something as ordinary as deleting one
            // memory.
            //
            // The trade is stated honestly rather than claimed away: this
            // resolve is *unscoped*, so for an excluded ordinary album it
            // replaces sixty small indexed queries with one full walk. That
            // is a worse peak for that case, not a better one. It is
            // accepted here and not in the widget — which bounds its own via
            // `MemoryLibrary.exclusionContext(on:)` — because this runs in
            // the app on a detached utility task, where a transient spike
            // costs latency, while the widget runs in an extension where the
            // same spike is a jetsam kill that freezes the home screen. The
            // bound cannot simply be reused here anyway: these are sixty
            // different days, so there is no single date predicate to pass.
            let exclusions = MemoryExclusions.Context.current()
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
                    MemoryLibrary.count(on: target, calendar: calendar, exclusions: exclusions)
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
                // `.era` included, so the year is never ambiguous.
                //
                // Under the Japanese calendar `.year` is era-relative — 8,
                // not 2026 — and these components go straight to
                // `UNCalendarNotificationTrigger`. ICU almost certainly
                // defaults an unset era to the current one and resolves it
                // correctly, but "almost certainly" is the wrong standard for
                // sixty reminders whose alternative is firing in Meiji 8.
                // Requesting the era costs nothing and removes the
                // assumption.
                let components = calendar.dateComponents(
                    [.era, .year, .month, .day, .hour, .minute],
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
