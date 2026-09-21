import Foundation
import Photos

nonisolated struct YearGroup: Identifiable {
    let id: Int
    let year: Int
    let assets: [PHAsset]
    /// The year written the way the reader's own calendar writes it.
    ///
    /// `year` is a proleptic Gregorian number, because that is the only way
    /// the anniversary arithmetic survives an era boundary — see
    /// `MemoryWindow.anniversaryCalendar`. Printing it raw would show 2025 to
    /// someone on the Buddhist calendar, where every other date in the app
    /// reads 2568.
    ///
    /// Derived from the group's own anniversary instant rather than from a
    /// fixed anchor. A previous version formatted 1 July of the Gregorian
    /// year, reasoning that era boundaries fall mid-year — true for Japanese
    /// eras, and irrelevant for the two calendars whose *year* boundary is
    /// not 1 January. Under the Hebrew calendar, every anniversary from
    /// September to December sat in the next Hebrew year than 1 July did, so
    /// all twenty headers were off by one while the photo's own date line,
    /// two taps away, disagreed with them. Formatting a date the group
    /// actually contains cannot drift from the group's contents.
    ///
    /// Stored, not computed: it was being read inside a `map` over every
    /// asset, so it built a `Calendar` and ran a `FormatStyle` once per
    /// photo, per body evaluation.
    let displayYear: String
    private let referenceYear: Int

    init(
        year: Int,
        assets: [PHAsset],
        anniversary: Date,
        referenceYear: Int = MemoryWindow.anniversaryCalendar().component(.year, from: Date())
    ) {
        self.id = year
        self.year = year
        self.assets = assets
        self.displayYear = anniversary.formatted(.dateTime.year())
        self.referenceYear = referenceYear
    }

    /// Used only by `filtered`, which already holds a rendered label.
    private init(year: Int, assets: [PHAsset], displayYear: String, referenceYear: Int) {
        self.id = year
        self.year = year
        self.assets = assets
        self.displayYear = displayYear
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
        return YearGroup(year: year, assets: kept, displayYear: displayYear, referenceYear: referenceYear)
    }
}

nonisolated enum MemoryLibrary {
    private typealias AnniversaryRange = (year: Int, start: Date, end: Date, anniversary: Date)

    /// The anniversary windows the gallery and the notification count both read.
    ///
    /// Shared deliberately: `CLAUDE.md` treats the two surfaces disagreeing as a
    /// contract violation, and the only way to guarantee they agree is for both
    /// to derive their date ranges here.
    private static func anniversaryRanges(on date: Date, calendar: Calendar) -> [AnniversaryRange] {
        // Gregorian, so the stride below is over absolute years. See
        // `MemoryWindow.anniversaryCalendar` — under the Japanese calendar
        // this component is an era-relative 8, and the lookback ran to -12.
        let calendar = MemoryWindow.anniversaryCalendar(calendar)
        let currentYear = calendar.component(.year, from: date)
        return stride(
            from: currentYear - 1,
            through: currentYear - MemoryWindow.lookbackYears,
            by: -1
        ).compactMap { year -> AnniversaryRange? in
            guard let range = MemoryWindow.range(for: date, anniversaryYear: year, calendar: calendar) else {
                return nil
            }
            // The anniversary itself, not the widened window's start, which
            // with a day window can fall in the previous year. Carried so a
            // group can be labelled with a date its own photos share.
            let anniversary = MemoryWindow.range(
                for: date, anniversaryYear: year, dayWindow: 0, calendar: calendar
            )?.start ?? range.start
            return (year, range.start, range.end, anniversary)
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

    /// The exclusion context a fetch on `date` builds for itself.
    ///
    /// Exposed for a caller that makes more than one call for the same date
    /// and wants to resolve exclusions once. Reaching for
    /// `MemoryExclusions.Context.current()` to do that is the trap: its
    /// default argument leaves the album lookup *unbounded*, which turns one
    /// small indexed query per excluded album into a full enumeration of
    /// every member of it. That is the exact cost
    /// `excludedAlbumMemberIdentifiers(matching:)` documents as the thing
    /// that kills the widget extension, so the one caller that most needs to
    /// resolve once is also the one that can least afford to resolve
    /// unbounded. This keeps both properties.
    ///
    /// The date predicate is the same one `yearGroups` and `count` build, so
    /// a context from here is indistinguishable from the one either would
    /// have made privately.
    static func exclusionContext(
        on date: Date,
        calendar: Calendar = .current
    ) -> MemoryExclusions.Context {
        let ranges = anniversaryRanges(on: date, calendar: calendar)
        // No anniversary windows means both fetches return nothing without
        // consulting exclusions at all, so there is nothing to resolve.
        guard !ranges.isEmpty else { return .unfiltered }
        return .current(matching: datePredicate(for: ranges))
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
        let currentYear = MemoryWindow.anniversaryCalendar(calendar).component(.year, from: date)
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
            return YearGroup(
                year: item.year,
                assets: assets,
                anniversary: item.anniversary,
                referenceYear: currentYear
            )
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
