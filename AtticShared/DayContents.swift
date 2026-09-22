import Foundation
import Photos

/// Everything in the library from one calendar day.
///
/// Deliberately not part of `MemoryLibrary`, and the tripwire in
/// `MemoryCountSourceTests` enforces that: that type answers one question —
/// what counts as a memory on a date — and it answers it with exactly one
/// fetch so the gallery and the widget cannot disagree. This answers a
/// different question, and putting a second fetch in that file would retire
/// the guarantee.
///
/// The difference is not cosmetic. A memory is filtered: it honours the
/// anniversary window and the "Feature Less Often" exclusions. A day is not
/// filtered at all. The whole point of showing the rest of a day is that it
/// can be checked against the Photos app, and a number that quietly omitted
/// the photos someone had asked Attic to feature less often would fail that
/// check for no reason they could see. "Feature Less Often" governs what
/// Attic *chooses* to surface, not what exists.
///
/// Nothing here may feed the gallery summary, the notification count or the
/// widget. It walks a whole day, which on a wedding or a holiday is hundreds
/// of assets — fine for a screen the user asked for, fatal inside a widget
/// extension's memory budget.
nonisolated enum DayContents {
    /// One day's assets, and how many there really were.
    nonisolated struct Result {
        /// Oldest first, capped at the caller's limit.
        let assets: [PHAsset]
        /// Before the cap, so the UI can say "showing the first 500 of 1,842"
        /// rather than quietly lying.
        let totalCount: Int
        let start: Date
        let end: Date
    }

    /// Everything from the logical day containing `date`.
    ///
    /// Synchronous and `nonisolated`, matching `MemoryLibrary.yearGroups`: the
    /// caller owns the hop off the main actor. That is not a detail to skip —
    /// this target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and
    /// `NonisolatedNonsendingByDefault`, so an `async` wrapper that is merely
    /// `nonisolated` runs on its caller's executor, and every caller here is a
    /// SwiftUI view. Only `@concurrent`, or an explicit `Task.detached`, moves
    /// this off the main thread — and on an eight-hundred-photo day the
    /// difference is a visible freeze.
    static func onDay(
        containing date: Date,
        calendar: Calendar = .current,
        dayStartHour: Int = MemoryWindow.dayStartHour,
        maxItems: Int = 500
    ) -> Result? {
        guard let bounds = MemoryWindow.dayBounds(
            containing: date,
            dayStartHour: dayStartHour,
            calendar: calendar
        ) else { return nil }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@",
            bounds.start as NSDate,
            bounds.end as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        // Left at its default of false, and it must stay that way. Photos puts
        // the Hidden album behind Face ID; surfacing those here would be a
        // privacy break wearing a feature's clothes.
        options.includeHiddenAssets = false

        let result = PHAsset.fetchAssets(with: options)

        var assets: [PHAsset] = []
        var total = 0
        result.enumerateObjects { asset, _, _ in
            guard AssetEligibility.isBrowsable(asset),
                  AssetEligibility.isRepresentative(asset) else { return }
            total += 1
            // Counting continues past the cap, so `totalCount` is the truth
            // even when `assets` is not all of it.
            if assets.count < maxItems {
                assets.append(asset)
            }
        }

        return Result(assets: assets, totalCount: total, start: bounds.start, end: bounds.end)
    }

    /// Roughly how many items that day holds, without materialising any.
    ///
    /// Used only to decide whether to offer the day at all — a day holding
    /// just the memory already on screen has nothing to show. The number is
    /// never displayed, because a count taken behind a predicate counts by a
    /// different rule than membership decided in Swift: bursts and media type
    /// are filtered above and cannot be expressed here. That gap is exactly
    /// how the widget came to report one memory fewer than the app, so this
    /// one is allowed to be approximate and is forbidden from being shown.
    static func approximateCount(
        containing date: Date,
        calendar: Calendar = .current,
        dayStartHour: Int = MemoryWindow.dayStartHour
    ) -> Int {
        guard let bounds = MemoryWindow.dayBounds(
            containing: date,
            dayStartHour: dayStartHour,
            calendar: calendar
        ) else { return 0 }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@",
            bounds.start as NSDate,
            bounds.end as NSDate
        )
        options.includeHiddenAssets = false
        return PHAsset.fetchAssets(with: options).count
    }
}
