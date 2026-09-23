#if ATTIC_SIDELOAD
import Foundation

/// A switch for Pro that exists only in builds made for sideloading.
///
/// The whole file compiles to nothing unless `ATTIC_SIDELOAD` is set, and
/// that flag is passed on the command line by the sideload workflow alone —
/// it is in no stored build setting, and `SideloadFlagTripwireTests` fails if
/// it ever appears in one. An App Store build therefore contains no code for
/// this at all, rather than containing it switched off. That distinction is
/// the point: a hidden switch that unlocks a paid feature is both a free
/// unlock for anyone who finds it and an App Review rejection under 2.3.1,
/// which bars "hidden, dormant, or undocumented features".
nonisolated enum SideloadSettings {
    static let proUnlockedKey = "Attic.sideload.proUnlocked"

    /// Where the switch starts, decided by how the build was made.
    static var buildDefault: Bool {
        #if ATTIC_SIDELOAD_PRO
        return true
        #else
        return false
        #endif
    }

    /// Stored in the shared suite so the widget would follow it wherever the
    /// App Group is actually granted. A re-signed build does not get the
    /// group, so there the widget reads its own empty store and falls back to
    /// `buildDefault` — which is why the Settings footer says the widget
    /// follows the build rather than the switch.
    static var proUnlocked: Bool {
        get { AtticDefaults.shared.object(forKey: proUnlockedKey) as? Bool ?? buildDefault }
        set { AtticDefaults.shared.set(newValue, forKey: proUnlockedKey) }
    }
}
#endif
