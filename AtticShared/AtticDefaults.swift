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
    ///
    /// The stakes went up when "Feature Less Often" started living here too.
    /// An unprovisioned group means the widget reads an empty exclusion list
    /// and will happily put a photo the user explicitly hid on their home or
    /// lock screen. The memory window merely disagreeing is a bug; that one
    /// breaks a promise the app made, in the most visible place it could.
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
    nonisolated(unsafe) static let shared: UserDefaults = {
        guard isAppGroupAvailable, let suite = UserDefaults(suiteName: appGroupIdentifier) else {
            return .standard
        }
        return suite
    }()

    /// Whether the App Group is actually provisioned for this process.
    ///
    /// `UserDefaults(suiteName:)` is not a test for it. It hands back a store
    /// for a suite the process has no entitlement to reach, so the nil-check
    /// this used to rely on passed in exactly the case it was meant to catch,
    /// and the app and the widget each read a private store while appearing
    /// to share one. Asking for the group's container directory is the check
    /// that actually fails without the entitlement.
    ///
    /// Worth surfacing rather than only tolerating: when this is false the
    /// widget silently renders the free-tier memory window and an empty
    /// exclusion list, which reads to the user as the widget disagreeing with
    /// the app for no reason.
    ///
    /// Compiled out off-Apple. App Groups are an Apple sandbox concept, and
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` is not part of
    /// the Foundation the package builds against on Windows, where this file
    /// is compiled for the shared logic tests.
    static var isAppGroupAvailable: Bool {
        #if canImport(Darwin)
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) != nil
        #else
        return false
        #endif
    }

    /// The last Pro entitlement `PurchaseStore` observed.
    ///
    /// Stored in the shared suite because the processes that need to honour
    /// it cannot ask StoreKit: the widget runs in its own extension, and
    /// `MemoryWindow` is read from a detached task in the notification
    /// scheduler. It authorizes nothing — `Transaction.currentEntitlements`
    /// remains the only source of truth for whether Pro was bought — and is
    /// read solely to decide whether the two Pro *settings* apply.
    ///
    /// Being a cache, it can be briefly wrong, and the design assumes so: a
    /// stale `false` shows free-tier behaviour until the next refresh
    /// corrects it, and nothing is lost either way. That tolerance is the
    /// whole point. The previous approach reset the stored settings to their
    /// free defaults on a false reading, which turned every transient into
    /// permanent, unrecoverable destruction of a paying user's preferences —
    /// and an entitlement that merely fails verification, as happens on
    /// device clock skew, reads exactly like an absent one.
    static var isProEntitled: Bool {
        get {
            // A sideloaded build decides Pro with a switch, and `PurchaseStore`
            // records the answer — but only into the *app's* store. Re-signing
            // drops the App Group, so the widget cannot read it. Answering
            // from `SideloadSettings` here means the widget falls back to the
            // build's starting position rather than to free.
            //
            // That depends on the widget being compiled with the flag, which
            // for a long time it was not: its build configurations never read
            // `ATTIC_EXTRA_SWIFT_FLAGS`, so this branch was compiled into the
            // app alone and every sideloaded widget ran the free version.
            // `SideloadFlagTripwireTests` now fails if either target stops
            // reading it.
            #if ATTIC_SIDELOAD
            return SideloadSettings.proUnlocked
            #else
            return shared.bool(forKey: proEntitlementKey)
            #endif
        }
        set { shared.set(newValue, forKey: proEntitlementKey) }
    }

    static let proEntitlementKey = "Attic.lastObservedProEntitlement"

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
