import Foundation

/// Where settings that more than one process has to agree on are kept.
///
/// A widget extension runs in its own process with its own container, so
/// `UserDefaults.standard` inside the widget is *not* the app's
/// `UserDefaults.standard` — the two never see each other's writes. Anything
/// the widget must read the same way the app does has to live in a shared App
/// Group suite instead.
///
/// Only the settings that change *which photos count as today's* belong here.
/// The notification preferences deliberately do not: nothing outside the app
/// schedules notifications, so moving them would be churn with no reader.
nonisolated enum AtticDefaults {
    /// Must match the App Group enabled on both targets in the developer
    /// portal and the `com.apple.security.application-groups` entitlement.
    static let appGroupIdentifier = "group.Patrick-App.TimeCapsule"

    /// Falls back to `.standard` when the App Group is not provisioned.
    ///
    /// Deliberately a soft failure. In the app the fallback behaves exactly as
    /// things did before the group existed; in the widget it means the widget
    /// reads its own defaults and so renders the free-tier window. A widget
    /// that disagrees with the app is a worse outcome than one that agrees,
    /// and a better one than a crash — but it is silent, which is why
    /// provisioning the group is called out on the release checklist.
    /// `nonisolated(unsafe)` because `UserDefaults` is not `Sendable`, which
    /// makes a static one an error under the Swift 6 language mode the package
    /// builds in. It is the right annotation rather than a silencer:
    /// `UserDefaults` is documented as thread-safe and synchronises its own
    /// access, which is the "external synchronization mechanism" the
    /// compiler's own diagnostic points at.
    ///
    /// The alternative it suggests — `@MainActor` — would be actively wrong.
    /// `MemoryWindow` is nonisolated and is read from a detached task in the
    /// notification scheduler and from the widget's own process, none of which
    /// are on the main actor.
    nonisolated(unsafe) static let shared: UserDefaults =
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard

    /// Copies settings written before the App Group existed.
    ///
    /// Without this, someone who had already widened their memory range would
    /// find it silently back at the default after updating, because the value
    /// sits in the app's own defaults and nothing reads there any more.
    ///
    /// Runs once. Afterwards the shared suite is the only authority, so a key
    /// the user has since reset is never resurrected from the old store.
    static func migrateIfNeeded() {
        let migrationKey = "Attic.didMigrateSharedDefaults"
        guard shared !== UserDefaults.standard, !shared.bool(forKey: migrationKey) else { return }

        for key in [MemoryWindow.storageKey, MemoryWindow.dayStartHourKey] {
            if shared.object(forKey: key) == nil,
               let existing = UserDefaults.standard.object(forKey: key) {
                shared.set(existing, forKey: key)
            }
        }
        shared.set(true, forKey: migrationKey)
    }
}
