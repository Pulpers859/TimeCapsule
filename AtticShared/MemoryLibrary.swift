import Foundation
import Photos

nonisolated struct YearGroup: Identifiable {
    let id: Int
    let year: Int
    let assets: [PHAsset]
    private let referenceYear: Int

    init(year: Int, assets: [PHAsset], referenceYear: Int = Calendar.current.component(.year, from: Date())) {
        self.id = year
        self.year = year
        self.assets = assets
        self.referenceYear = referenceYear
    }

    var yearsAgo: Int {
        referenceYear - year
    }

    var label: String {
        yearsAgo == 1 ? "1 Year Ago" : "\(yearsAgo) Years Ago"
    }

    /// Narrows the group, keeping the year it is measured against. `nil` when
    /// nothing survives, so a caller can drop the group entirely.
    ///
    /// Exists so filtering cannot quietly lose `referenceYear`. Rebuilding a
    /// group with `YearGroup(year:assets:)` falls back to the *wall-clock*
    /// year, and these groups are built against the **logical** year, which
    /// differs whenever a late day start is set and the clock has passed
    /// midnight. On New Year's morning that shifted every label by a year —
    /// the grid said "2 Years Ago" over a photo the viewer called "1 year
    /// ago", on the one night of the year people photograph most.
    func filtered(_ isIncluded: (PHAsset) -> Bool) -> YearGroup? {
        let kept = assets.filter(isIncluded)
        guard !kept.isEmpty else { return nil }
        return YearGroup(year: year, assets: kept, referenceYear: referenceYear)
    }
}

nonisolated enum MemoryLibrary {
    private typealias AnniversaryRange = (year: Int, start: Date, end: Date)

    /// The anniversary windows the gallery and the notification count both read.
    ///
    /// Shared deliberately: `CLAUDE.md` treats the two surfaces disagreeing as a
    /// contract violation, and the only way to guarantee they agree is for both
    /// to derive their date ranges here.
    private static func anniversaryRanges(on date: Date, calendar: Calendar) -> [AnniversaryRange] {
        let currentYear = calendar.component(.year, from: date)
        return stride(
            from: currentYear - 1,
            through: currentYear - MemoryWindow.lookbackYears,
            by: -1
        ).compactMap { year -> AnniversaryRange? in
            guard let range = MemoryWindow.range(for: date, anniversaryYear: year, calendar: calendar) else {
                return nil
            }
            return (year, range.start, range.end)
        }
    }

    private static func datePredicate(for ranges: [AnniversaryRange]) -> NSPredicate {
        NSCompoundPredicate(orPredicateWithSubpredicates: ranges.map { item in
            NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@",
                item.start as NSDate,
                item.end as NSDate
            )
        })
    }

    /// Matches the `mediaType == .image || mediaType == .video` test that
    /// `yearGroups` applies while enumerating. Expressed as a predicate so
    /// `count(on:)` can let Photos do the filtering instead of materialising
    /// every asset to check it in Swift.
    ///
    /// Built per call rather than held in a `static let`: `NSPredicate` is not
    /// `Sendable`, and this type is `nonisolated`, so a stored instance would
    /// be shared mutable global state. Constructing one is trivial next to the
    /// fetch it configures.
    private static func mediaTypePredicate() -> NSPredicate {
        NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
    }

    /// - Parameter maxPerYear: caps how many assets each year retains. The
    ///   gallery wants all of them and passes nil; the widget shows at most
    ///   four and passes a small number.
    ///
    ///   Without a cap this holds on to a `PHAsset` for every match across
    ///   the whole lookback — with a widened memory range that is a 15-day
    ///   window across 20 years, which on a heavy library is a lot of
    ///   objects to build inside a widget extension's jetsam limit purely to
    ///   use four of them. A capped caller must take its total from
    ///   `count(on:)` rather than by summing the groups, which is what that
    ///   method is for.
    static func yearGroups(
        on date: Date,
        calendar: Calendar = .current,
        exclusions: MemoryExclusions.Context? = nil,
        maxPerYear: Int? = nil
    ) -> [YearGroup] {
        let currentYear = calendar.component(.year, from: date)
        let ranges = anniversaryRanges(on: date, calendar: calendar)
        guard !ranges.isEmpty else { return [] }

        let dates = datePredicate(for: ranges)
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = dates
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        // Resolved here, rather than as a default argument, so the album
        // half of it can be bounded by the very same date predicate this
        // fetch uses. Excluding a large album otherwise costs a full walk of
        // that album on every call — which is what kills the widget.
        let exclusions = exclusions ?? .current(matching: dates)
        let result = PHAsset.fetchAssets(with: fetchOptions)
        var assetsByYear: [Int: [PHAsset]] = [:]
        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video,
                  let creationDate = asset.creationDate,
                  let matchingYear = ranges.first(where: {
                      creationDate >= $0.start && creationDate < $0.end
                  })?.year,
                  !exclusions.excludes(asset) else {
                return
            }
            if let maxPerYear, assetsByYear[matchingYear]?.count ?? 0 >= maxPerYear { return }
            assetsByYear[matchingYear, default: []].append(asset)
        }

        return ranges.compactMap { item in
            guard let assets = assetsByYear[item.year], !assets.isEmpty else { return nil }
            return YearGroup(year: item.year, assets: assets, referenceYear: currentYear)
        }
    }

    /// Number of memories on `date`, without building any of them.
    ///
    /// This used to call `yearGroups(on:)` and sum the arrays it returned,
    /// which meant materialising a `PHAsset` for every match and then throwing
    /// them all away. `NotificationManager` calls this once per day for the
    /// next 60 days on every schedule, so on a large library that was tens of
    /// thousands of wasted object allocations per refresh.
    ///
    /// `PHFetchResult.count` answers from the fetch itself and never
    /// materialises a row. The media-type filter moves into the predicate so
    /// the result stays identical to what `yearGroups` would have counted.
    static func count(
        on date: Date,
        calendar: Calendar = .current,
        exclusions: MemoryExclusions.Context? = nil
    ) -> Int {
        let ranges = anniversaryRanges(on: date, calendar: calendar)
        guard !ranges.isEmpty else { return 0 }

        let dates = datePredicate(for: ranges)
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            dates,
            mediaTypePredicate()
        ])
        let result = PHAsset.fetchAssets(with: fetchOptions)
        let exclusions = exclusions ?? .current(matching: dates)

        // No exclusions is the common case, and it keeps the fast path this
        // was written for: `.count` answers straight from the fetch without
        // materialising a `PHAsset` for anything. Once an exclusion exists,
        // answering correctly needs to look at each candidate, but the set
        // that survives the date predicate is small — a handful of photos
        // taken on one calendar date across however many years back — so
        // this is nowhere near the per-day full-library walk that made
        // `count(on:)` a "scan storm" before.
        guard !exclusions.isEmpty else { return result.count }

        var count = 0
        result.enumerateObjects { asset, _, _ in
            if !exclusions.excludes(asset) {
                count += 1
            }
        }
        return count
    }

}
