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

    static func yearGroups(on date: Date, calendar: Calendar = .current) -> [YearGroup] {
        let currentYear = calendar.component(.year, from: date)
        let ranges = anniversaryRanges(on: date, calendar: calendar)
        guard !ranges.isEmpty else { return [] }

        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = datePredicate(for: ranges)
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let result = PHAsset.fetchAssets(with: fetchOptions)
        var assetsByYear: [Int: [PHAsset]] = [:]
        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video,
                  let creationDate = asset.creationDate,
                  let matchingYear = ranges.first(where: {
                      creationDate >= $0.start && creationDate < $0.end
                  })?.year else {
                return
            }
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
    static func count(on date: Date, calendar: Calendar = .current) -> Int {
        let ranges = anniversaryRanges(on: date, calendar: calendar)
        guard !ranges.isEmpty else { return 0 }

        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            datePredicate(for: ranges),
            mediaTypePredicate()
        ])
        return PHAsset.fetchAssets(with: fetchOptions).count
    }

}
